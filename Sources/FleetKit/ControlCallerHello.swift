import Foundation

/// What a local CLI puts in its `hello`'s `caller` field: the tab's token, and — when it runs
/// inside a codex command — the codex thread that ran it.
///
/// **Why the thread rides along.** Every codex tab on an account attaches to that account's
/// one shared app-server daemon, and codex runs each tab's shell commands from inside that
/// daemon. The daemon's environment, `FLIGHT_DECK_CALLER` included, is whichever tab happened
/// to start it, so measured on 2026-10-24 every codex tab's `flightdeck` presented the same
/// tab's token: a peer reply was addressed from the wrong tab and a send to that tab was
/// refused as "this same tab". Codex sets `CODEX_THREAD_ID` per command, which is the one
/// per-tab fact that survives the shared process. The token still has to verify; the thread
/// only chooses among the codex tabs that token's account shares a daemon with.
///
/// One string rather than a new wire field, so the `hello` shape is unchanged and a plain token
/// from an older CLI still verifies. The CLI and the app ship in one bundle, so the reverse
/// pairing (a suffixed caller reaching an app that predates this) does not arise.
public enum ControlCallerHello {
    static let threadMarker = "#codex-thread="

    /// The thread rides along even with no token: a daemon Flight Deck itself started carries no
    /// tab's token, and its commands would otherwise present nothing at all.
    public static func compose(environment: [String: String]) -> String? {
        let token = environment["FLIGHT_DECK_CALLER"].flatMap { $0.isEmpty ? nil : $0 }
        guard let thread = environment["CODEX_THREAD_ID"].flatMap(UUID.init(uuidString:)) else { return token }
        return (token ?? "") + threadMarker + thread.uuidString.lowercased()
    }

    public static func split(_ caller: String?) -> (token: String?, codexThread: UUID?) {
        guard let caller, let range = caller.range(of: threadMarker) else { return (caller, nil) }
        let token = String(caller[..<range.lowerBound])
        return (token.isEmpty ? nil : token, UUID(uuidString: String(caller[range.upperBound...])))
    }
}
