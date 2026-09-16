// Sources/FlightDeck/SessionDaemon.swift
import Foundation

/// Owns the socket/pidfile/binary-path layout `fd-abduco` needs to detach and re-attach a
/// session's shell, independent of Flight Deck's own process lifetime. Pure value type: no
/// liveness checks, no process spawning, no wiring into `SessionStore` — those are later tasks.
/// This is only the arithmetic that turns a session id into the handful of space-free strings
/// every other piece agrees on.
///
/// **Why the symlink.** `bundledBinary` lives inside the app bundle, e.g.
/// `/Applications/Flight Deck.app/Contents/Resources/fd-abduco` — a path containing a space.
/// That space is fatal downstream: the command strings this type builds get handed to
/// ghostty's shell-command tokenizer, which splits on whitespace with no quoting support (see
/// `ClaudeFlagQuoting.swift` for the sibling problem this already caused for CLI flags). So
/// `resolvedBinaryPath` keeps a symlink under `directory` — already guaranteed space-free,
/// being `/tmp/flight-deck-<uid>` — and only that symlink's path is ever assembled into a
/// command.
struct SessionDaemon {
    /// Root for every socket, pidfile and the binary symlink. `/tmp/flight-deck[-debug]-<uid>`
    /// rather than a per-app-support directory: abduco's control socket is a Unix domain socket,
    /// and `sun_path` is capped at 104 bytes on macOS — `/tmp` keeps the fixed prefix short
    /// enough to leave room for the uuid regardless of the logged-in user's home directory depth.
    let directory: URL

    /// The real, space-containing on-disk binary. `nil` when running outside a real app bundle
    /// (e.g. `swift test`), in which case `resolvedBinaryPath` throws rather than silently
    /// producing a symlink to nothing.
    let bundledBinary: URL?

    /// `directory: nil` resolves to `defaultDirectory()` — the build-specific root. Pass an
    /// explicit directory to override it (tests inject a temp dir; `makeStore` threads the
    /// `-FlightDeckDaemonDir` launch arg through here).
    init(
        directory: URL? = nil,
        bundledBinary: URL? = Bundle.main.url(forResource: "fd-abduco", withExtension: nil)
    ) {
        self.directory = directory ?? SessionDaemon.defaultDirectory()
        self.bundledBinary = bundledBinary
    }

    /// True in a Debug build, false in Release — the `-D DEBUG` flag the Debug configuration
    /// compiles with. Exposed as a value (not just `#if`) so `defaultDirectory(debug:)` can be
    /// exercised for both builds from a single test run.
    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    /// The default socket/pidfile root, **different between Debug and Release builds**
    /// (`/tmp/flight-deck-debug-<uid>` vs `/tmp/flight-deck-<uid>`). This is what keeps a locally
    /// launched debug build from ever sharing the directory a released build uses: `restore()`'s
    /// `reconcileDaemons` reaps every daemon in *its own* `directory` that isn't in the sessions
    /// it restored, so two builds that never share a directory can never reap each other's
    /// daemons. Overridable via the `directory:` init param.
    static func defaultDirectory(debug: Bool = isDebugBuild) -> URL {
        URL(fileURLWithPath: "/tmp/flight-deck-\(debug ? "debug-" : "")\(getuid())")
    }

    enum PathError: Error, CustomStringConvertible {
        /// `resolvedBinaryPath` was asked to link to nothing — the app bundle does not ship
        /// `fd-abduco` (or this is a non-bundle test host that never injected a fake one).
        case binaryNotBundled

        var description: String {
            switch self {
            case .binaryNotBundled:
                return "fd-abduco is not bundled with this build"
            }
        }
    }

    func socketPath(for id: UUID) -> String {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).sock").path
    }

    func pidfilePath(for id: UUID) -> String {
        socketPath(for: id) + ".pid"
    }

    /// Idempotent: `withIntermediateDirectories: true` treats an already-existing directory as
    /// success rather than an error.
    func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // `createDirectory` does not update permissions on a directory that already exists
        // (the attributes are only applied at creation time), so a leftover directory from a
        // stale run — or one whose mode drifted for any other reason — is re-tightened here on
        // every call instead of just the first.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
    }

    /// Ensures `<directory>/fd-abduco` is a symlink to `bundledBinary` and returns its
    /// (space-free) path. Safe to call repeatedly, including across app versions that moved
    /// `bundledBinary` to a new path: an existing link is only left alone when it already
    /// points at the right target, and is removed and recreated otherwise.
    func resolvedBinaryPath() throws -> String {
        guard let bundledBinary else { throw PathError.binaryNotBundled }
        try ensureDirectory()

        let linkURL = directory.appendingPathComponent("fd-abduco")
        let linkPath = linkURL.path
        let fileManager = FileManager.default

        if let existingTarget = try? fileManager.destinationOfSymbolicLink(atPath: linkPath) {
            if existingTarget == bundledBinary.path {
                return linkPath
            }
            try fileManager.removeItem(atPath: linkPath)
        }

        try fileManager.createSymbolicLink(
            atPath: linkPath, withDestinationPath: bundledBinary.path
        )
        return linkPath
    }

    func attachCommand(for id: UUID) throws -> String {
        "\(try resolvedBinaryPath()) -a \(socketPath(for: id))"
    }

    func coldCreateCommand(for id: UUID, shell: String) throws -> String {
        "\(try resolvedBinaryPath()) -c \(socketPath(for: id)) \(shell)"
    }

    /// Every session id `directory` currently has a `.sock` file for — a directory listing,
    /// not a liveness probe (see `DaemonControlling.isLive` for that). This is what a launch
    /// reconcile walks to find daemons whose session no longer appears in a restored snapshot:
    /// `sessions.json` only names what the *last run* thought was open, but the directory
    /// names what is actually still on disk right now.
    ///
    /// A filename that does not parse as `<uuid>.sock` is silently skipped rather than
    /// treated as an error: the `fd-abduco` symlink and each socket's `.pid` sidecar both live
    /// alongside the sockets in the same directory, and neither ends in `.sock`, so the
    /// suffix check alone already excludes them — this only guards against anything else that
    /// might land here.
    func liveSessionIDs() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".sock") else { return nil }
            return UUID(uuidString: String(name.dropLast(".sock".count)))
        }
    }
}
