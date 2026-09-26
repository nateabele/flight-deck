import FleetKit
import Foundation

/// Why a `session`/`project` token in a `flightdeck` command line didn't resolve to exactly
/// one id.
public enum CLIResolveError: Error, Equatable {
    /// `self` was given, and this invocation carries no self id — e.g. run outside any
    /// Flight Deck-managed session.
    case noSelf
    /// The token matched nothing, named verbatim so the CLI can echo it back.
    case notFound(String)
    /// The token matched more than one candidate — every id it matched, so the CLI can list
    /// them for the caller to disambiguate with a longer prefix.
    case ambiguous(String, [UUID])
}

/// Resolves the loose tokens a human types on a command line — `self`, a UUID, a title, a
/// prefix of a UUID, `.`/`here`, a path, a name — against a `FleetSnapshot`, to the one id (if any)
/// they name.
public enum CLISessionResolver {
    /// The shortest prefix `flightdeck` will treat as a prefix search rather than requiring an
    /// exact match. Below this, "abc" naming three different `abc…` sessions by accident is a
    /// near-certainty rather than a rare collision, so it is refused outright instead of
    /// silently becoming an ambiguity list.
    private static let minimumPrefixLength = 4

    public static func session(
        _ token: String, in fleet: FleetSnapshot, selfID: UUID?
    ) -> Result<UUID, CLIResolveError> {
        if token == "self" {
            guard let selfID else { return .failure(.noSelf) }
            return .success(selfID)
        }

        let sessions = fleet.projects.flatMap(\.sessions)

        if let exact = UUID(uuidString: token) {
            if let match = sessions.first(where: { $0.id == exact }) {
                return .success(match.id)
            }
            // A syntactically valid UUID that names no session is still just "not found" —
            // it does not fall through to prefix or title matching, both of which a full
            // UUID could otherwise spuriously satisfy.
            return .failure(.notFound(token))
        }

        // Titles before prefixes: a tab titled `cafe` must resolve to itself, never to another
        // tab whose id happens to start with `CAFE`. The title is what the user meant; a
        // prefix match on it is a coincidence of hex spelling.
        let titleMatches = sessions.filter { $0.title == token }
        switch titleMatches.count {
        case 1: return .success(titleMatches[0].id)
        case let n where n > 1: return .failure(.ambiguous(token, titleMatches.map(\.id)))
        default: break // fall through to prefix matching
        }

        if token.count >= minimumPrefixLength {
            let lowered = token.lowercased()
            let prefixMatches = sessions.filter { $0.id.uuidString.lowercased().hasPrefix(lowered) }
            switch prefixMatches.count {
            case 1: return .success(prefixMatches[0].id)
            case let n where n > 1:
                return .failure(.ambiguous(token, prefixMatches.map(\.id)))
            default: break
            }
        }

        return .failure(.notFound(token))
    }

    public static func project(
        _ token: String, in fleet: FleetSnapshot, cwd: String
    ) -> Result<UUID, CLIResolveError> {
        if token == "." || token == "here" {
            // The longest ancestor wins: `/w/a` and `/w/a/nested` are both ancestors of
            // `/w/a/nested/src`, and the nested one is the project actually current.
            let ancestors = fleet.projects.filter { isAncestor($0.path, of: cwd) }
            if let closest = ancestors.max(by: { $0.path.count < $1.path.count }) {
                return .success(closest.id)
            }
            return .failure(.notFound(token))
        }

        if let byPath = fleet.projects.first(where: { $0.path == token }) {
            return .success(byPath.id)
        }

        let nameMatches = fleet.projects.filter { $0.name == token }
        switch nameMatches.count {
        case 1: return .success(nameMatches[0].id)
        case let n where n > 1: return .failure(.ambiguous(token, nameMatches.map(\.id)))
        default: break // fall through to UUID prefix matching
        }

        if token.count >= minimumPrefixLength {
            let lowered = token.lowercased()
            let prefixMatches = fleet.projects.filter { $0.id.uuidString.lowercased().hasPrefix(lowered) }
            switch prefixMatches.count {
            case 1: return .success(prefixMatches[0].id)
            case let n where n > 1: return .failure(.ambiguous(token, prefixMatches.map(\.id)))
            default: break
            }
        }

        return .failure(.notFound(token))
    }

    /// `path` is `cwd` itself, or a directory containing it — `/w/a` is an ancestor of
    /// `/w/a/nested/src`, but NOT of `/w/abc` (a naive `hasPrefix` would wrongly say yes).
    private static func isAncestor(_ path: String, of cwd: String) -> Bool {
        cwd == path || cwd.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }
}
