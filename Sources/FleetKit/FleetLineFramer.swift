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

    init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        let cap = Self.maximumLineLength
        while true {
            var lineLength: Int?
            var overflow = false
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: cap + 1) { buffer, _ in
                guard let buffer else { return 0 }
                if let newline = buffer.firstIndex(of: 0x0A) { lineLength = newline }
                else if buffer.count > cap { overflow = true }
                return 0
            }
            // Failing the connection is the whole defence: a peer that never sends a newline
            // would otherwise have the stack buffer its bytes without limit.
            if overflow { framer.markFailed(error: .posix(.EMSGSIZE)); return 0 }
            guard parsed, let length = lineLength else { return 0 }
            let message = NWProtocolFramer.Message(definition: Self.definition)
            _ = framer.deliverInputNoCopy(length: length, message: message, isComplete: true)
            _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 1) { _, _ in 1 }
        }
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                      messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
        framer.writeOutput(data: Data([0x0A]))
    }
}
