import Foundation
import HostKit

/// Names the holder of a local port for preflight step 4 (spec §7), and offers a free one.
///
/// Flight Deck's own forwards are asked first. lsof would name them too, but as "Flight Deck
/// (pid 4410)", which sends the user hunting for a process to kill when the fix is
/// `flightdeck down` in the session that owns it.
struct LocalPortHolder: PortChecking {
    /// The session title holding a local forward, from `PortForwarder`.
    let ownForward: @Sendable (UInt16) -> String?
    /// lsof (and Docker, for a container publishing the port on this Mac) via HostKit.
    var check = PortCheck()
    var isFree: @Sendable (UInt16) -> Bool = { PortCheck.isFree($0) }

    func holder(of port: UInt16) async -> PortHolder {
        if let session = ownForward(port) { return .flightDeck(session: session) }
        // lsof and `docker ps` block for up to seconds; keep them off the cooperative pool.
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: isFree(port) ? .free : check.name(holderOf: port) ?? .unknown)
            }
        }
    }

    /// A free local port to suggest instead of `port`, never one of `claimed` (the ports this
    /// same request asked for), so the retry the message proposes cannot collide with itself.
    func suggestion(for port: UInt16, claimed: Set<UInt16>) -> UInt16? {
        PortCheck.suggestFree(near: port, excluding: claimed, isFree: { ownForward($0) == nil && isFree($0) })
    }
}
