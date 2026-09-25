import FleetKit
import Foundation

/// The socket, as `CLIRunner` sees it: frames in, commands and requests out.
///
/// A protocol rather than `FleetClient` itself so the runner's whole state machine — the
/// snapshot gate, reconnect-and-resume, `cid` correlation — can be driven one frame at a time
/// by a test, with no socket and no Flight Deck running. The real conformer is the binary's
/// `LocalFleetTransport`, and it is the only file that touches a socket.
protocol CLITransport: AnyObject {
    var onFrame: ((ServerFrame) -> Void)? { get set }
    /// Fired for a refused connect as well as a dropped one — the runner tells the two apart
    /// by whether any frame ever arrived, since a CLI has no other signal that it got through.
    var onDisconnect: ((Error?) -> Void)? { get set }
    func connect(lastSeq: Int)
    /// Returns the `cid` the command went out under, which its `ack`/`err` will echo.
    @discardableResult func send(_ command: FleetCommand) -> Int
    /// Returns the `cid` the request went out under, which its reply will echo.
    @discardableResult func send(_ request: FleetRequest) -> Int
    /// A frame exactly as `flightdeck raw` decoded it, `cid` included — no numbering applied.
    func send(raw frame: ClientFrame)
    func disconnect()
}
