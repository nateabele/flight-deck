import Foundation
import Network

/// Newline-delimited framing for the local control socket.
///
/// **Not WebSocket, because WebSocket cannot run here.** `NWProtocolWebSocket` over a
/// `.unix(path:)` endpoint aborts the client with `ECONNABORTED` before `.ready` (probed
/// 2026-09-24; see the spec). The frames themselves are the same `ClientFrame`/`ServerFrame`
/// JSON the phone speaks. Only the framing differs, and `JSONEncoder` never emits a raw
/// newline (it escapes the ones inside strings), so a newline is an unambiguous terminator.
///
/// A framer rather than hand-reassembly so `FleetSocket.receive` keeps using `receiveMessage`
/// and delivering whole frames. Both transports share one send/receive path.
final class FleetLineFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: FleetLineFramer.self)
    static var label: String { "FleetLines" }

    /// Set once, before any listener or connection is built. `NWProtocolFramer` instantiates
    /// this type itself, so a per-instance value has nowhere to come from. The cap is the same
    /// one the WebSocket side uses (`TimelineLimits.maximumMessageSize`). Tests lower it to
    /// prove it fails closed.
    nonisolated(unsafe) static var maximumLineLength = TimelineLimits.maximumMessageSize

    /// The current line's bytes so far. `parseInput` only hands over what the stack already
    /// holds contiguously, which on a unix socket is one read: 8192 bytes. The framer used to
    /// leave a newline-less buffer in place and wait, but the stack never offered more than
    /// that first read, so a line longer than 8 KiB was neither delivered nor failed — the
    /// connection just hung. That is how a 22.9 KB fleet snapshot froze every `flightdeck`
    /// command (a fake server put the cutoff at exactly 8192: 8,133 B worked, 8,333 B hung).
    /// Growing `minimumIncompleteLength` does not rescue it: probed, the stack then coalesces
    /// exactly that many bytes and does not call back until *new* bytes arrive, so it stalls
    /// one byte later. Consuming every read into this buffer is what lets the next read in.
    /// Per-instance, because `NWProtocolFramer` makes one framer per connection.
    private var pending = Data()

    init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        let cap = Self.maximumLineLength
        while true {
            var consumed = 0
            var complete = false
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: cap + 1) { buffer, _ in
                guard let buffer, !buffer.isEmpty else { return 0 }
                if let newline = buffer.firstIndex(of: 0x0A) {
                    pending.append(contentsOf: buffer[..<newline])
                    complete = true
                    consumed = newline + 1   // the newline is framing, never part of the line
                } else {
                    pending.append(contentsOf: buffer)
                    consumed = buffer.count
                }
                return consumed
            }
            // Failing the connection is the whole defence: a peer that never sends a newline
            // would otherwise have this buffer grow without limit. Checked on the accumulated
            // line, not one read, so the cap holds at its real value above 8 KiB too.
            if pending.count > cap { framer.markFailed(error: .posix(.EMSGSIZE)); return 0 }
            guard parsed, consumed > 0 else { return 0 }
            guard complete else { continue }
            let message = NWProtocolFramer.Message(definition: Self.definition)
            framer.deliverInput(data: pending, message: message, isComplete: true)
            pending = Data()
        }
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                      messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
        framer.writeOutput(data: Data([0x0A]))
    }
}
