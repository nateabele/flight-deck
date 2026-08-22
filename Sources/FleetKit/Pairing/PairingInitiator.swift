import Foundation
import Network

/// One pairing attempt against one endpoint: the phone's half of the exchange.
///
/// Callback-shaped rather than `async`, matching `FleetClient`, because the caller is a
/// `PairingRunner` walking a list of Macs and a SwiftUI screen showing progress — both want to
/// be told, not to await.
///
/// **This ships in FleetKit rather than in the phone app**, for the reason `FleetClient`'s own
/// doc gives: the loopback tests drive the real thing, and a second, test-only initiator would
/// prove nothing about the one that ships.
///
/// `@unchecked Sendable` with every mutation confined to `queue` — the same discipline as
/// `FleetClient`. **Every** method and every Network.framework callback asserts
/// `dispatchPrecondition(condition: .onQueue(queue))` as its first line, the way
/// `PairingListener` does: they were all already on `queue`, but only some of them said so, and
/// a confinement discipline that is asserted at four sites out of eight is one a later change
/// can leave silently — the assertions are how "confined to `queue`" stays a fact rather than
/// becoming a comment.
public final class PairingInitiator: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The Mac rejected our confirmation, or its own did not verify, or the sealed blob
        /// did not open. All three mean the same thing to the user — the code did not match
        /// this Mac — and only one of them costs an attempt on the Mac's counter.
        case wrongCode
        /// This Mac's window is burned. The user must arm again, not retype.
        case attemptsExhausted
        /// Never reached the Mac at all. Distinct from `wrongCode` because it sends the user
        /// to the network, not to the keyboard.
        case connectionFailed
        /// The Mac spoke, and what it said was not this protocol. It also carries one local
        /// failure that is not the Mac's fault at all, knowingly — see `start()`'s `catch`.
        case malformedResponse
    }

    public var onPaired: ((_ key: FleetDeviceKey, _ macName: String) -> Void)?
    public var onFailure: ((Failure) -> Void)?

    /// The deadline for the **whole exchange**, not just for reaching the Mac: it is armed
    /// once in `start()` and never re-armed, so it bounds TLS, the WebSocket upgrade and all
    /// four frames together. A Mac that completes TLS and then stalls before the sealed frame
    /// reports `.connectionFailed` at this deadline, which is what a pairing screen needs — a
    /// peer that answered and went quiet is exactly as unpairable as a dead address, and
    /// `NWConnection` will wait out either one well past any patience the screen has.
    ///
    /// Named for what it bounds rather than for the connect it starts with, because the other
    /// name invites lengthening it "for slow networks" without noticing that it also caps the
    /// crypto round-trips — and a runner walking three discovered Macs pays it once per Mac.
    public var exchangeTimeout: TimeInterval = 8

    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var session: SPAKE2Session?
    private var secrets: PairingSecrets?
    /// Guards `onPaired`/`onFailure` so exactly one fires, once. Three paths reach a verdict —
    /// a frame, a state change, the timeout — and one dropped socket trips at least two of
    /// them, because `receiveMessage` errors at the same moment the state goes `.failed`.
    private var settled = false
    /// Invalidates a timeout that outlived its attempt: `asyncAfter` cannot be cancelled, so
    /// the block recognises staleness instead. A runner starts several attempts in a row on
    /// one initiator's lifetime, and an earlier timeout firing into a later attempt would
    /// abandon a live exchange.
    private var generation = 0

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func start(code: PairingCode, endpoint: NWEndpoint) {
        dispatchPrecondition(condition: .onQueue(queue))
        cancel()
        settled = false
        generation += 1
        let generation = self.generation

        session = SPAKE2Session(
            role: .initiator,
            myName: PairingChannel.initiatorName, theirName: PairingChannel.responderName
        )

        // The same 16 KiB inbound cap the Mac's listener imposes, and for the same reason
        // (`PairingListener.maxFrameBytes`): the phone dials a Bonjour advertisement that
        // anyone on the LAN holding a copy of the binary can publish, so its peer here is
        // exactly as unauthenticated as the listener's. The whole server vocabulary is a
        // 32-byte curve point, a 32-byte MAC and a sealed key of a few hundred bytes; the
        // 1 MiB fleet default would let a spoofed advertisement make the stack buffer a
        // megabyte before any of this code sees a frame.
        let parameters = FleetSocket.webSocketParameters(
            FleetTLS.pairingClientParameters(),
            maximumMessageSize: PairingListener.maxFrameBytes
        )
        let connection = NWConnection(
            to: FleetSocket.webSocketEndpoint(for: endpoint), using: parameters
        )
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            switch state {
            case .ready:
                guard let session = self.session, let connection = self.connection else {
                    return
                }
                do {
                    // The first frame goes the instant the socket is usable. The bootstrap PSK
                    // has established nothing about who is on the other end — that is what the
                    // next three frames are for.
                    FleetSocket.send(
                        PairingClientFrame.pake(msg: try session.message(for: code)),
                        over: connection
                    )
                } catch {
                    // Mislabelled, and deliberately so: nothing has been received at this
                    // point, so what failed is our own `session.message(for:)`, not the Mac's
                    // half of the protocol. It keeps `.malformedResponse` rather than earning
                    // a case of its own because that call throws only if BoringSSL fails
                    // inside this process — unreachable short of a broken build — and a
                    // public case no peer can provoke is an arm every consumer has to write
                    // user-facing copy for. The verdict the copy would give is the one
                    // `.malformedResponse` already gives: this Mac did not pair, try again.
                    self.fail(.malformedResponse)
                }
            case .failed, .cancelled:
                self.fail(.connectionFailed)
            default:
                break
            }
        }

        FleetSocket.receive(PairingServerFrame.self, from: connection) { [weak self] frame in
            guard let self, !self.settled else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            self.handle(frame)
        } onEnd: { [weak self] _ in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            self.fail(.connectionFailed)
        }

        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + exchangeTimeout) { [weak self] in
            guard let self, generation == self.generation else { return }
            self.fail(.connectionFailed)
        }
    }

    public func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        settled = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        session = nil
        secrets = nil
    }

    private func handle(_ frame: PairingServerFrame) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let session, let connection else { return }
        switch frame {
        case .pake(let peerMessage):
            do {
                let material = try session.keyMaterial(from: peerMessage)
                // `session.transcript`, never `mine + peerMessage`. It is initiator-first on
                // both sides precisely so neither caller gets to choose — see that property's
                // doc comment for the failure the choice produces.
                let derived = PairingSecrets(
                    keyMaterial: material, transcript: try session.transcript
                )
                secrets = derived
                FleetSocket.send(
                    PairingClientFrame.confirm(mac: derived.initiatorConfirmation),
                    over: connection
                )
            } catch {
                fail(.malformedResponse)
            }

        case .sealed(let mac, let box):
            guard let secrets else { return fail(.malformedResponse) }
            // Checked BEFORE the box is opened, and that ordering is the point: a peer that
            // cannot prove it knew the code has not earned an attempt at handing this phone a
            // device key. `matches` is constant-time.
            guard PairingSecrets.matches(mac, secrets.responderConfirmation) else {
                return fail(.wrongCode)
            }
            guard let opened = try? secrets.open(box) else { return fail(.wrongCode) }
            finish(key: opened.key, macName: opened.macName)

        case .reject(let reason):
            switch reason {
            case .badCode, .malformed: fail(.wrongCode)
            case .attemptsExhausted: fail(.attemptsExhausted)
            }
        }
    }

    private func finish(key: FleetDeviceKey, macName: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !settled else { return }
        settled = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        onPaired?(key, macName)
    }

    private func fail(_ failure: Failure) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !settled else { return }
        settled = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        onFailure?(failure)
    }
}
