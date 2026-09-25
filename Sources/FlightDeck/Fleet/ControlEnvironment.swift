import CryptoKit
import Foundation

/// The `flightdeck` CLI's socket location and the per-tab identity a launched process presents
/// on it: where the control socket lives, the HMAC token that names which tab is calling, and
/// the environment variables a tab is launched with so a script inside it can find both.
///
/// **The token is derived, not stored.** `token(for:secret:)` recomputes a session's caller
/// token from its id and the persisted secret every time, rather than generating one at launch
/// and writing it down — so a tab detached under fd-abduco and re-attached after a Flight Deck
/// relaunch still presents a token this build recognizes, with nothing to persist per session
/// and nothing to go stale.
///
/// **This is a guardrail, not a secret boundary.** The secret lives in `UserDefaults`, and any
/// process running as this user can read another process's environment (`ps -e -o command`,
/// `/proc`-equivalent inspection) or the defaults domain directly. The HMAC exists to stop a
/// tab from typo'ing or guessing its way into naming a *different* session — not to withstand a
/// hostile process on the same account.
enum ControlEnvironment {
    /// `defaults write dev.flightdeck.FlightDeck FlightDeckControlSocket -bool NO` turns the
    /// socket off. Read once per launch, same as `AnswerTrigger.defaultsKey` — see that type's
    /// doc comment for why a live toggle isn't worth the extra lifecycle.
    static let enabledKey = "FlightDeckControlSocket"
    /// Where the 32-byte HMAC secret is persisted, so it survives a relaunch — see the type's
    /// doc comment on why the token must be re-derivable rather than newly minted each time.
    static let secretKey = "FlightDeckControlSecret"

    static let sessionVariable = "FLIGHT_DECK_SESSION_ID"
    static let socketVariable = "FLIGHT_DECK_CONTROL_SOCKET"
    static let callerVariable = "FLIGHT_DECK_CALLER"

    /// On by default: the socket is meant to be there for the CLI to find, and off is the
    /// opt-out. The `defaults` parameter is the same test seam `AnswerTrigger.isEnabled` and
    /// `FlightDeckApp.stateDirectory(_:)` use — a suite of its own instead of the real domain.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// `debug` picks the filename, not the directory — the caller decides where `stateDirectory`
    /// points (real state dir, or a test's temp directory), same division of labor as
    /// `SessionDaemon.defaultDirectory(debug:)`. Debug and Release get different filenames so a
    /// locally launched debug build never answers a release build's control socket, or the
    /// reverse.
    static func socketURL(stateDirectory: URL, debug: Bool) -> URL {
        stateDirectory.appendingPathComponent(debug ? "control-debug.sock" : "control.sock")
    }

    /// True in a Debug build, false in Release — mirrors `SessionDaemon.isDebugBuild`.
    #if DEBUG
    private static let isDebugBuild = true
    #else
    private static let isDebugBuild = false
    #endif

    /// The running build's own control socket path. Mirrors
    /// `AppDelegate.answerTriggerURL()`'s directory expression exactly, so the control socket
    /// and the answer-trigger socket always land in the same directory.
    ///
    /// `@MainActor` because `FileSessionPersistence.defaultDirectory()` is: it is the same
    /// isolation `answerTriggerURL()` itself runs under, not something this type adds.
    @MainActor
    static func socketURL() -> URL {
        socketURL(
            stateDirectory: FlightDeckApp.stateDirectory() ?? FileSessionPersistence.defaultDirectory(),
            debug: isDebugBuild
        )
    }

    /// The persisted HMAC secret, generating and storing one the first time this is asked.
    /// Reading the same `defaults` domain back always returns the same 32 bytes — that
    /// stability, not secrecy, is what keeps a session's token valid across a relaunch.
    static func secret(_ defaults: UserDefaults = .standard) -> Data {
        if let existing = defaults.data(forKey: secretKey), existing.count == 32 {
            return existing
        }
        var bytes = Data(count: 32)
        // SecRandomCopyBytes only fails when the system's random source is unavailable, which
        // is not a condition this can recover from or usefully report — the precondition
        // crashes rather than silently handing out a weak or all-zero secret.
        let status = bytes.withUnsafeMutableBytes { pointer in
            SecRandomCopyBytes(kSecRandomDefault, 32, pointer.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        defaults.set(bytes, forKey: secretKey)
        return bytes
    }

    /// `<session-uuid>.<hex hmac>` — the session id is left in the clear (a caller needs it to
    /// know which tab it is) and the HMAC over it is what a forger cannot produce without the
    /// secret.
    static func token(for session: UUID, secret: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(session.uuidString.utf8), using: SymmetricKey(data: secret)
        )
        return "\(session.uuidString).\(hex(mac))"
    }

    /// The session a token claims, or `nil` if the token is malformed, names a session whose id
    /// doesn't parse, or its MAC doesn't match what this secret would have produced — the last
    /// case covers both a tampered MAC and a token minted under a different secret.
    ///
    /// Recomputing the expected token and comparing the two strings (rather than decoding the
    /// hex and calling `HMAC.isValidAuthenticationCode` on the bytes) is the simpler of the two
    /// options the brief allows, and equally fine at this trust level: nothing here defends
    /// against a timing attack, since the secret is already only as protected as the rest of
    /// this user's environment (see the type's doc comment).
    static func session(forToken token: String, secret: Data) -> UUID? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let session = UUID(uuidString: String(parts[0])) else { return nil }
        guard token == ControlEnvironment.token(for: session, secret: secret) else { return nil }
        return session
    }

    /// The three variables a launched tab needs to reach this Mac's control socket as itself:
    /// which session it is, where the socket is, and the token that proves it without the CLI
    /// having to ask the user to name a session by hand.
    static func variables(for session: UUID, socket: URL, secret: Data) -> [String: String] {
        [
            sessionVariable: session.uuidString,
            socketVariable: socket.path,
            callerVariable: token(for: session, secret: secret),
        ]
    }

    private static func hex(_ mac: HMAC<SHA256>.MAC) -> String {
        mac.map { String(format: "%02x", $0) }.joined()
    }
}
